// #66 (54-R0, rulings D2, D3b): the reveal request holder. `request` stamps a
// sequence number and the current `tabsProvider.arrivals`; `take(noteId)`
// hands out the pending request for that note and clears it either way.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

/// A container whose `tabsProvider` is a plain notifier with no tab open.
ProviderContainer _wi66Container() {
  final container = ProviderContainer(
    overrides: [
      tabsProvider.overrideWith(
        (ref) => TabsNotifier(
          store: UiStateStore(vaultPath: '/dev/null'),
          onPersistedSelection: (_) {},
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

NoteRevealNotifier _wi66Reveal(ProviderContainer c) =>
    c.read(noteRevealProvider.notifier);

void main() {
  group('the D2 types', () {
    test(
      'the D2 types carry their fields and flash and leaveSource default to false',
      () {
        // Built from run-time values, so the constructors run.
        final n = DateTime(2026, 11, 18).day;
        final byte = RevealAtByte(n);
        final text = RevealAtText(
          segment: n - 16,
          start: n,
          end: n + 4,
          content: 'c$n',
        );
        final card = RevealAtCard(segment: n - 17, content: 'k$n');
        final top = RevealTop(n - 2.0);
        final within = RevealWithin(n * 3.0);
        const third = RevealThird();
        final r = NoteRevealRequest('note-$n', text, top);

        expect(byte.startByte, 18);
        expect(const RevealAtByte(null).startByte, isNull);
        expect(text.segment, 2);
        expect(text.start, 18);
        expect(text.end, 22);
        expect(text.content, 'c18');
        expect(RevealAtText(segment: 0, start: n, content: '').end, isNull);
        expect(card.segment, 1);
        expect(card.content, 'k18');
        expect(top.inset, 16.0);
        expect(within.topInset, 54.0);
        expect(third, isA<RevealPlacement>());
        expect(r.noteId, 'note-18');
        expect(r.at, same(text));
        expect(r.placement, same(top));
        expect(r.flash, isFalse);
        expect(r.leaveSource, isFalse);
        final both = NoteRevealRequest(
          'note-$n',
          byte,
          within,
          flash: n > 0,
          leaveSource: n > 0,
        );
        expect(both.flash, isTrue);
        expect(both.leaveSource, isTrue);
      },
    );
  });

  group('request', () {
    test(
      'request stamps a rising sequence number and the current tabs arrivals',
      () {
        final c = _wi66Container();
        final tabs = c.read(tabsProvider.notifier);
        tabs.navigate(const NoteTab('a'));
        tabs.navigate(const NoteTab('b'));
        final arrivalsThen = c.read(tabsProvider).arrivals;
        const first = NoteRevealRequest('b', RevealAtByte(3), RevealThird());

        _wi66Reveal(c).request(first);

        final one = c.read(noteRevealProvider);
        expect(one, isNotNull);
        expect(one!.request, same(first));
        expect(one.arrivals, arrivalsThen);

        tabs.navigate(const NoteTab('c'));
        const second = NoteRevealRequest('c', RevealAtByte(5), RevealThird());
        _wi66Reveal(c).request(second);

        final two = c.read(noteRevealProvider)!;
        expect(two.request, same(second), reason: 'replaces the earlier one');
        expect(two.arrivals, c.read(tabsProvider).arrivals);
        expect(two.arrivals, isNot(arrivalsThen));
        expect(two.seq, greaterThan(one.seq));
      },
    );

    test(
      'two equal requests notify twice and carry different sequence numbers',
      () {
        final c = _wi66Container();
        c.read(tabsProvider.notifier).navigate(const NoteTab('a'));
        final seen = <PendingReveal?>[];
        c.listen(noteRevealProvider, (_, next) => seen.add(next));
        const r = NoteRevealRequest('a', RevealAtByte(7), RevealTop(16));

        _wi66Reveal(c).request(r);
        _wi66Reveal(c).request(r);

        expect(seen, hasLength(2));
        expect(seen[0]!.request, same(r));
        expect(seen[1]!.request, same(r));
        expect(seen[1]!.seq, isNot(seen[0]!.seq));
      },
    );
  });

  group('take', () {
    test('take returns the pending request for its note and clears it', () {
      final c = _wi66Container();
      c.read(tabsProvider.notifier).navigate(const NoteTab('a'));
      const r = NoteRevealRequest(
        'a',
        RevealAtText(segment: 0, start: 4, content: 'body'),
        RevealTop(16),
        flash: true,
      );
      _wi66Reveal(c).request(r);
      expect(c.read(noteRevealProvider), isNotNull);

      expect(_wi66Reveal(c).take('a'), same(r));

      expect(c.read(noteRevealProvider), isNull);
      expect(_wi66Reveal(c).take('a'), isNull, reason: 'one shot');
    });

    test(
      'take for another note returns null and clears the pending request',
      () {
        final c = _wi66Container();
        c.read(tabsProvider.notifier).navigate(const NoteTab('a'));
        const r = NoteRevealRequest('a', RevealAtByte(1), RevealThird());
        _wi66Reveal(c).request(r);
        expect(c.read(noteRevealProvider), isNotNull);

        expect(_wi66Reveal(c).take('b'), isNull);

        expect(c.read(noteRevealProvider), isNull);
        expect(_wi66Reveal(c).take('a'), isNull, reason: 'cleared either way');
      },
    );
  });
}
