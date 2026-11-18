// WI #80 (Spec #61 F1, TD1): the app-wide Find in note state and its
// commands (Reqs 12-15, 18-19, 37-42), driven through a ProviderContainer.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';

/// Body segment 0 holds `bread` at 0, 10 and 20; card segment 1 one at 6.
final List<FindSource> _sources = [
  const FindSource(
    segment: 0,
    kind: FindSourceKind.body,
    text: 'bread one bread two bread',
  ),
  const FindSource(segment: 1, kind: FindSourceKind.card, text: 'fresh bread'),
];

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

FindInNoteState _state(ProviderContainer c) => c.read(findInNoteProvider);
FindInNoteNotifier _find(ProviderContainer c) =>
    c.read(findInNoteProvider.notifier);

/// A container with [_sources] given, [query] typed in an open bar, then
/// closed again, so the last query is [query].
ProviderContainer _withLastQuery(String query, {FindCaret? caret}) {
  final c = _container();
  _find(c)
    ..setSources(_sources)
    ..setCaret(caret)
    ..show()
    ..setQuery(query)
    ..close();
  return c;
}

void main() {
  test('findInNoteProvider starts closed with nothing in it', () {
    final s = _state(_container());
    expect(s.open, isFalse);
    expect(s.query, '');
    expect(s.lastQuery, '');
    expect(s.sources, isEmpty);
    expect(s.matches, isEmpty);
    expect(s.current, isNull);
    expect(s.caret, isNull);
    expect(s.focusRequest, 0);
  });

  group('show (Reqs 12-13)', () {
    test(
      'show on a closed state opens with the last query and the current match from the caret',
      () {
        final c = _withLastQuery('bread', caret: const FindCaret(0, 5));
        final before = _state(c).focusRequest;
        expect(_state(c).open, isFalse);

        _find(c).show();

        final s = _state(c);
        expect(s.open, isTrue);
        expect(s.query, 'bread');
        expect(s.matches, findMatches(_sources, 'bread'));
        expect(s.matches, hasLength(4));
        expect(s.current, 1, reason: 'first match at or after (0, 5) is at 10');
        expect(s.focusRequest, before + 1);
      },
    );

    test('show with a never placed caret starts at the first match', () {
      final c = _withLastQuery('bread');
      _find(c).show();
      expect(_state(c).current, 0);
      expect(_state(c).open, isTrue);
    });

    test('show on an open state only bumps focusRequest', () {
      final c = _container();
      _find(c)
        ..setSources(_sources)
        ..show()
        ..setQuery('bread');
      _find(c).next();
      final before = _state(c);
      expect(before.current, 1);

      _find(c).show();

      final s = _state(c);
      expect(s.open, isTrue);
      expect(s.query, 'bread');
      expect(s.matches, before.matches);
      expect(s.current, 1);
      expect(s.focusRequest, before.focusRequest + 1);
    });
  });

  group('lastQuery (Reqs 12, 40, 42)', () {
    test(
      'lastQuery starts empty follows every setQuery and survives close and noteChanged',
      () {
        final c = _container();
        expect(_state(c).lastQuery, '');
        _find(c)
          ..setSources(_sources)
          ..show()
          ..setQuery('br');
        expect(_state(c).lastQuery, 'br');
        _find(c).setQuery('bread');
        expect(_state(c).lastQuery, 'bread');
        expect(_state(c).query, 'bread');

        _find(c).close();
        expect(_state(c).lastQuery, 'bread');

        _find(c).show();
        expect(_state(c).query, 'bread');
        _find(c).noteChanged();
        expect(_state(c).lastQuery, 'bread');

        _find(c).show();
        expect(_state(c).query, 'bread');
        _find(c).setQuery('');
        expect(_state(c).lastQuery, '');
      },
    );
  });

  group('setQuery (Req 18)', () {
    test(
      'setQuery recomputes the matches and takes the current match from the caret',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..setCaret(const FindCaret(0, 11))
          ..show()
          ..setQuery('bread');
        expect(_state(c).matches, hasLength(4));
        expect(_state(c).current, 2);

        // Moving the caret never moves the current match.
        _find(c).setCaret(const FindCaret(0, 0));
        expect(_state(c).current, 2);
        expect(_state(c).caret, const FindCaret(0, 0));

        // A new query starts from the caret again.
        _find(c).setQuery('fresh');
        expect(_state(c).matches, [
          const FindMatch(
            segment: 1,
            kind: FindSourceKind.card,
            start: 0,
            end: 5,
          ),
        ]);
        expect(_state(c).current, 0);

        _find(c).setQuery('');
        expect(_state(c).matches, isEmpty);
        expect(_state(c).current, isNull);
        expect(_state(c).open, isTrue);
      },
    );
  });

  group('useSelection (Req 14)', () {
    test(
      'useSelection turns line breaks into spaces sets the query and opens the bar',
      () {
        final c = _container();
        _find(c)
          ..setSources([
            const FindSource(
              segment: 0,
              kind: FindSourceKind.body,
              text: 'bread\none and bread one',
            ),
          ])
          ..useSelection('bread\none');

        final s = _state(c);
        expect(s.open, isTrue);
        expect(s.query, 'bread one');
        expect(s.lastQuery, 'bread one');
        expect(s.matches, [
          const FindMatch(
            segment: 0,
            kind: FindSourceKind.body,
            start: 14,
            end: 23,
          ),
        ]);
        expect(s.current, 0);
        // Focus stays in the editor.
        expect(s.focusRequest, 0);
      },
    );

    test('useSelection with an empty text changes nothing', () {
      final c = _withLastQuery('bread');
      final before = _state(c);
      _find(c).useSelection('');
      final s = _state(c);
      expect(s.open, isFalse);
      expect(s.query, before.query);
      expect(s.lastQuery, 'bread');
      expect(s.matches, isEmpty);
      expect(s.focusRequest, before.focusRequest);
    });
  });

  group('next and previous (Reqs 15, 19)', () {
    test(
      'next and previous step with wrap and return the new current match',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..show()
          ..setQuery('bread');
        final matches = _state(c).matches;
        expect(_state(c).current, 0);

        expect(_find(c).previous(), matches[3]);
        expect(_state(c).current, 3);
        expect(_find(c).next(), matches[0]);
        expect(_state(c).current, 0);
        expect(_find(c).next(), matches[1]);
        expect(_state(c).current, 1);
      },
    );

    test(
      'next with the bar closed opens at firstAtOrAfter without bumping focusRequest',
      () {
        final c = _withLastQuery('bread', caret: const FindCaret(0, 10));
        final focus = _state(c).focusRequest;

        final m = _find(c).next();

        final s = _state(c);
        expect(s.open, isTrue);
        expect(s.query, 'bread');
        expect(s.current, 1);
        expect(m, s.matches[1]);
        expect(s.focusRequest, focus);
      },
    );

    test(
      'previous with the bar closed opens at lastBefore without bumping focusRequest',
      () {
        final c = _withLastQuery('bread', caret: const FindCaret(0, 10));
        final focus = _state(c).focusRequest;

        final m = _find(c).previous();

        final s = _state(c);
        expect(s.open, isTrue);
        expect(s.query, 'bread');
        expect(s.current, 0);
        expect(m, s.matches[0]);
        expect(s.focusRequest, focus);
      },
    );

    test('next and previous with an empty last query change nothing', () {
      final c = _container();
      _find(c).setSources(_sources);
      expect(_find(c).next(), isNull);
      expect(_find(c).previous(), isNull);
      final s = _state(c);
      expect(s.open, isFalse);
      expect(s.matches, isEmpty);
      expect(s.current, isNull);
      expect(s.focusRequest, 0);
    });

    test(
      'next and previous with a last query cleared to empty change nothing',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..show()
          ..setQuery('bread');
        expect(_state(c).matches, hasLength(4));
        _find(c)
          ..setQuery('')
          ..close();
        final focus = _state(c).focusRequest;
        expect(_state(c).lastQuery, '');

        expect(_find(c).next(), isNull);
        expect(_find(c).previous(), isNull);
        final s = _state(c);
        expect(s.open, isFalse);
        expect(s.matches, isEmpty);
        expect(s.current, isNull);
        expect(s.focusRequest, focus);
      },
    );

    test('next and previous on an open bar with no matches return null', () {
      final c = _container();
      _find(c)
        ..setSources(_sources)
        ..show()
        ..setQuery('rye');
      expect(_find(c).next(), isNull);
      expect(_find(c).previous(), isNull);
      expect(_state(c).current, isNull);
      expect(_state(c).open, isTrue);
    });
  });

  group('setSources (Reqs 37-38)', () {
    test(
      'setSources after an edit keeps the current match and recomputes the count',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..show()
          ..setQuery('bread');
        _find(c).next();
        expect(_state(c).current, 1);

        // A `bread` typed at the note top: the current match shifts to index 2.
        final edited = [
          const FindSource(
            segment: 0,
            kind: FindSourceKind.body,
            text: 'bread\nbread one bread two bread',
          ),
          _sources[1],
        ];
        _find(c).setSources(edited);

        final s = _state(c);
        expect(s.sources, edited);
        expect(s.matches, findMatches(edited, 'bread'));
        expect(s.matches, hasLength(5));
        expect(s.current, 2);
        expect(s.matches[2].start, 16);
      },
    );

    test('setSources without carry takes the current match from the caret', () {
      final c = _container();
      _find(c)
        ..setSources(_sources)
        ..setCaret(const FindCaret(0, 21))
        ..show()
        ..setQuery('bread');
      expect(_state(c).current, 3);
      _find(c).next();
      expect(_state(c).current, 0);

      _find(c).setSources(_sources, carry: false);
      expect(_state(c).current, 3);
      expect(_state(c).matches, hasLength(4));
    });

    test(
      'setSources gives a first match typed into a note with none a current match from the caret',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..setCaret(const FindCaret(0, 3))
          ..show()
          ..setQuery('rye');
        expect(_state(c).matches, isEmpty);
        expect(_state(c).current, isNull);

        final typed = [
          const FindSource(
            segment: 0,
            kind: FindSourceKind.body,
            text: 'rye bread rye',
          ),
        ];
        _find(c).setSources(typed);
        expect(_state(c).matches, hasLength(2));
        // Never a match count without a current match while open.
        expect(
          _state(c).current,
          firstAtOrAfter(_state(c).matches, const FindCaret(0, 3)),
        );
        expect(_state(c).current, 1);
      },
    );

    test('setSources while closed stores the sources and shows no matches', () {
      final c = _withLastQuery('bread');
      final edited = [_sources[1]];
      _find(c).setSources(edited);
      expect(_state(c).sources, edited);
      expect(_state(c).matches, isEmpty);
      expect(_state(c).current, isNull);

      _find(c).show();
      expect(_state(c).matches, findMatches(edited, 'bread'));
      expect(_state(c).matches, hasLength(1));
    });
  });

  group('close and noteChanged (Reqs 40, 42)', () {
    test(
      'close returns the current match and clears matches current and open',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..show()
          ..setQuery('bread');
        _find(c).next();
        expect(_state(c).matches, hasLength(4));
        expect(_state(c).current, 1);
        final current = _state(c).matches[1];

        expect(_find(c).close(), current);

        final s = _state(c);
        expect(s.open, isFalse);
        expect(s.matches, isEmpty);
        expect(s.current, isNull);
        expect(s.lastQuery, 'bread');
        // Closing again has no current match to give.
        expect(_find(c).close(), isNull);
      },
    );

    test(
      'noteChanged closes clears matches and current and keeps the last query',
      () {
        final c = _container();
        _find(c)
          ..setSources(_sources)
          ..setCaret(const FindCaret(0, 11))
          ..show()
          ..setQuery('bread');
        expect(_state(c).current, 2);

        _find(c).noteChanged();

        final s = _state(c);
        expect(s.open, isFalse);
        expect(s.matches, isEmpty);
        expect(s.current, isNull);
        expect(s.lastQuery, 'bread');
        // The new note has no caret yet and no sources until the editor gives
        // them.
        expect(s.caret, isNull);
        expect(s.sources, isEmpty);
      },
    );

    test('noteChanged then show starts the new note at its first match', () {
      final c = _container();
      _find(c)
        ..setSources(_sources)
        ..setCaret(const FindCaret(0, 11))
        ..show()
        ..setQuery('bread')
        ..noteChanged()
        ..setSources(_sources)
        ..show();
      expect(_state(c).open, isTrue);
      expect(_state(c).current, 0);
    });
  });
}
