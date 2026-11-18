// WI #80 (Spec #61 F1, TD1): state contracts the first test pass left
// unpinned (found in verify).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';

const _sources = [
  FindSource(
    segment: 0,
    kind: FindSourceKind.body,
    text: 'bread one bread two',
  ),
];

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('noteChanged keeps focusRequest so the bar does not refocus', () {
    final c = _container();
    final find = c.read(findInNoteProvider.notifier);
    find
      ..setSources(_sources)
      ..show()
      ..show()
      ..setQuery('bread');
    expect(c.read(findInNoteProvider).focusRequest, 2);

    find.noteChanged();

    expect(c.read(findInNoteProvider).focusRequest, 2);
    expect(c.read(findInNoteProvider).lastQuery, 'bread');
  });

  test(
    'show with an empty last query opens with no matches and no current',
    () {
      final c = _container();
      final find = c.read(findInNoteProvider.notifier)
        ..setSources(_sources)
        ..show();

      final s = c.read(findInNoteProvider);
      expect(s.open, isTrue);
      expect(s.query, '');
      expect(s.matches, isEmpty);
      expect(s.current, isNull);
      expect(s.currentMatch, isNull);
      expect(s.focusRequest, 1);

      // A query then gives a current match, readable as currentMatch.
      find.setQuery('bread');
      expect(
        c.read(findInNoteProvider).currentMatch,
        const FindMatch(
          segment: 0,
          kind: FindSourceKind.body,
          start: 0,
          end: 5,
        ),
      );
    },
  );

  test('setSources on an open bar clears current when no match is left', () {
    final c = _container();
    final find = c.read(findInNoteProvider.notifier)
      ..setSources(_sources)
      ..show()
      ..setQuery('bread');
    expect(c.read(findInNoteProvider).current, 0);

    find.setSources(const [
      FindSource(segment: 0, kind: FindSourceKind.body, text: 'rye'),
    ]);

    final s = c.read(findInNoteProvider);
    expect(s.matches, isEmpty);
    expect(s.current, isNull);
    expect(s.open, isTrue);
    expect(s.query, 'bread');
  });
}
