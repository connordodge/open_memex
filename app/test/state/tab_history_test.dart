// WI #265: TabHistory, the immutable per-tab history value class (Spec TD3).
// Pure Dart: no widgets, no providers. Offsets are read by walking with
// back/forward, so every assertion goes through the public API.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tab_history.dart';
import 'package:path/path.dart' as p;

/// Builds a history of [targets] (first is the oldest) with the last current.
TabHistory<String> _build(List<String> targets) {
  var h = TabHistory<String>.initial(targets.first);
  for (final t in targets.skip(1)) {
    h = h.push(t);
  }
  return h;
}

/// Moves [h] to [index] using back and forward only.
TabHistory<String> _at(TabHistory<String> h, int index) {
  // Bounded, so a history that does not move fails an assertion, not a hang.
  var r = h;
  for (var i = 0; i < 200 && r.index > index; i++) {
    r = r.back();
  }
  for (var i = 0; i < 200 && r.index < index; i++) {
    r = r.forward();
  }
  return r;
}

/// The scroll offset of every entry, oldest first, read by walking from the
/// first entry with forward.
List<double?> _offsets(TabHistory<String> h) {
  var w = _at(h, 0);
  final out = <double?>[w.scrollOffset];
  for (var i = 0; i < 200 && w.canGoForward; i++) {
    w = w.forward();
    out.add(w.scrollOffset);
  }
  return out;
}

/// Index, targets and offsets, for comparing a history before and after an
/// operation without relying on ==.
List<Object?> _snap(TabHistory<String> h) => [
  h.index,
  List<String>.of(h.entries),
  _offsets(h),
];

void _expectSnap(
  TabHistory<String> h, {
  required int index,
  required List<String> entries,
  List<double?>? offsets,
}) {
  expect(h.index, index, reason: 'index');
  expect(h.entries, entries, reason: 'entries');
  expect(h.current, entries[index], reason: 'current');
  if (offsets != null) {
    expect(_offsets(h), offsets, reason: 'offsets');
  }
}

void main() {
  group('initial', () {
    test('initial holds one current entry with no scroll offset', () {
      final h = TabHistory<String>.initial('a');
      _expectSnap(h, index: 0, entries: ['a'], offsets: [null]);
      expect(h.current, 'a');
      expect(h.scrollOffset, isNull);
      expect(h.canGoBack, isFalse);
      expect(h.canGoForward, isFalse);
    });

    test('the history cap is 100 entries', () {
      expect(kMaxTabHistoryEntries, 100);
    });
  });

  group('AC 1: no Flutter or Riverpod import', () {
    test('tab_history.dart imports neither flutter nor flutter_riverpod', () {
      final file = File(p.join('lib', 'src', 'state', 'tab_history.dart'));
      expect(file.existsSync(), isTrue);
      final source = file.readAsStringSync();
      final directive = RegExp(
        r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
        multiLine: true,
      );
      final uris = [for (final m in directive.allMatches(source)) m.group(1)!];
      expect(source, contains('class TabHistory<T>'));
      expect(
        uris.where(
          (u) =>
              u.startsWith('package:flutter/') ||
              u.startsWith('package:flutter_riverpod/') ||
              u.startsWith('package:riverpod/') ||
              u.contains('tabs_state.dart'),
        ),
        isEmpty,
      );
    });
  });

  group('push', () {
    test('push appends the target and makes it current', () {
      final h = TabHistory<String>.initial('a').push('b');
      _expectSnap(h, index: 1, entries: ['a', 'b']);
      expect(h.canGoBack, isTrue);
      expect(h.canGoForward, isFalse);
    });

    test('push after back drops the Forward entries', () {
      final h = _build(['a', 'b', 'c']).back();
      expect(h.canGoForward, isTrue);
      final pushed = h.push('d');
      _expectSnap(pushed, index: 2, entries: ['a', 'b', 'd']);
      expect(pushed.canGoForward, isFalse);
      expect(pushed.canGoBack, isTrue);
    });

    test('push after back to the first entry drops every later entry', () {
      final pushed = _at(_build(['a', 'b', 'c']), 0).push('z');
      _expectSnap(pushed, index: 1, entries: ['a', 'z']);
      expect(pushed.canGoForward, isFalse);
    });

    test('push of the target already current still appends it', () {
      final h = TabHistory<String>.initial('a').push('a');
      _expectSnap(h, index: 1, entries: ['a', 'a']);
    });
  });

  group('AC 3: the 100 entry cap', () {
    final names = [for (var i = 0; i < 101; i++) 'n$i'];

    test('a history at exactly 100 entries keeps all 100', () {
      final h = _build(names.sublist(0, 100));
      expect(h.entries, names.sublist(0, 100));
      expect(h.entries.length, kMaxTabHistoryEntries);
      expect(h.index, 99);
      expect(h.current, 'n99');
    });

    test('the 101st push drops the oldest and keeps 100', () {
      final h = _build(names.sublist(0, 100)).push(names[100]);
      expect(h.entries.length, kMaxTabHistoryEntries);
      expect(h.entries.first, 'n1');
      expect(h.entries, names.sublist(1));
      expect(h.index, 99);
      expect(h.current, 'n100');
      expect(h.canGoForward, isFalse);
    });

    test('the push past the cap keeps the scroll offsets of the survivors', () {
      var h = _build(names.sublist(0, 100));
      h = h.withScrollOffset(42.5); // entry n99
      h = h.push(names[100]);
      final offsets = _offsets(h);
      expect(offsets.length, 100);
      expect(offsets[98], 42.5, reason: 'n99 is now second to last');
      expect(offsets[99], isNull);
      expect(offsets.take(98), everyElement(isNull));
    });

    test('a push after back at 100 entries drops Forward before the cap', () {
      final h = _build(names.sublist(0, 100)).back().push('x');
      expect(h.entries.length, 100);
      expect(h.entries.first, 'n0', reason: 'nothing hit the cap');
      expect(h.entries[98], 'n98');
      expect(h.current, 'x');
      expect(h.index, 99);
    });

    test('pushing past the cap repeatedly keeps the newest 100', () {
      var h = _build(names.sublist(0, 100));
      for (var i = 0; i < 5; i++) {
        h = h.push('extra$i');
      }
      expect(h.entries.length, 100);
      expect(h.entries.first, 'n5');
      expect(h.entries.last, 'extra4');
      expect(h.index, 99);
    });
  });

  group('back and forward', () {
    test('back moves one entry toward the first', () {
      final h = _build(['a', 'b', 'c']).back();
      _expectSnap(h, index: 1, entries: ['a', 'b', 'c']);
      expect(h.canGoBack, isTrue);
      expect(h.canGoForward, isTrue);
    });

    test('forward moves one entry toward the last', () {
      final h = _at(_build(['a', 'b', 'c']), 0).forward();
      _expectSnap(h, index: 1, entries: ['a', 'b', 'c']);
      expect(h.canGoBack, isTrue);
      expect(h.canGoForward, isTrue);
    });

    test('back on the first entry returns a history equal to the original', () {
      final original = _at(_build(['a', 'b', 'c']), 0).withScrollOffset(7);
      final again = _at(_build(['a', 'b', 'c']), 0).withScrollOffset(7);
      final r = original.back();
      expect(r, again);
      expect(r, original);
      expect(r.index, 0);
      expect(r.canGoBack, isFalse);
    });

    test(
      'forward on the last entry returns a history equal to the original',
      () {
        final original = _build(['a', 'b', 'c']).withScrollOffset(3);
        final again = _build(['a', 'b', 'c']).withScrollOffset(3);
        final r = original.forward();
        expect(r, again);
        expect(r, original);
        expect(r.index, 2);
        expect(r.canGoForward, isFalse);
      },
    );

    test('canGoBack is false on the first entry and true after it', () {
      final first = _at(_build(['a', 'b', 'c']), 0);
      expect(first.canGoBack, isFalse);
      expect(first.forward().canGoBack, isTrue);
      expect(first.forward().forward().canGoBack, isTrue);
    });

    test('canGoForward is false on the last entry and true before it', () {
      final last = _build(['a', 'b', 'c']);
      expect(last.canGoForward, isFalse);
      expect(last.back().canGoForward, isTrue);
      expect(last.back().back().canGoForward, isTrue);
    });

    test('a single entry history cannot go either way', () {
      final h = TabHistory<String>.initial('a');
      expect(h.back(), TabHistory<String>.initial('a'));
      expect(h.forward(), TabHistory<String>.initial('a'));
    });
  });

  group('AC 5: back then forward keeps scroll offsets', () {
    test('back then forward returns to the same entry with offsets intact', () {
      var h = TabHistory<String>.initial('a').withScrollOffset(10);
      h = h.push('b').withScrollOffset(20);
      h = h.push('c').withScrollOffset(30);
      final r = h.back().forward();
      expect(r.index, 2);
      expect(r.current, 'c');
      expect(r.scrollOffset, 30);
      expect(_offsets(r), [10.0, 20.0, 30.0]);
      expect(r, h);
    });

    test('forward then back returns to the same middle entry and offset', () {
      var h = TabHistory<String>.initial('a').withScrollOffset(10);
      h = h.push('b').withScrollOffset(20);
      h = h.push('c');
      h = h.back();
      final r = h.back().forward();
      expect(r.current, 'b');
      expect(r.scrollOffset, 20);
      expect(r.back().scrollOffset, 10);
      expect(r.forward().scrollOffset, isNull);
    });
  });

  group('AC 6: withScrollOffset', () {
    test('withScrollOffset sets the offset of the current entry', () {
      final h = TabHistory<String>.initial('a').withScrollOffset(12.5);
      expect(h.scrollOffset, 12.5);
      expect(h.current, 'a');
      expect(h.index, 0);
    });

    test('withScrollOffset changes only the current entry', () {
      var h = _build(['a', 'b', 'c']);
      h = _at(h, 1).withScrollOffset(5);
      expect(_offsets(h), [null, 5.0, null]);
      expect(h.index, 1);
      expect(h.entries, ['a', 'b', 'c']);
    });

    test('withScrollOffset overwrites an earlier offset on the same entry', () {
      final h = TabHistory<String>.initial(
        'a',
      ).withScrollOffset(1).withScrollOffset(2);
      expect(h.scrollOffset, 2);
    });

    test('withScrollOffset accepts zero as a real offset, not null', () {
      final h = TabHistory<String>.initial('a').withScrollOffset(0);
      expect(h.scrollOffset, 0.0);
      expect(h.scrollOffset, isNotNull);
    });

    test('a pushed entry starts with a null offset', () {
      final h = TabHistory<String>.initial('a').withScrollOffset(99).push('b');
      expect(h.scrollOffset, isNull);
      expect(h.back().scrollOffset, 99);
    });

    test('withScrollOffset does not move the index or the Forward entries', () {
      final h = _build(['a', 'b', 'c']).back().withScrollOffset(8);
      _expectSnap(h, index: 1, entries: ['a', 'b', 'c']);
      expect(h.canGoForward, isTrue);
      expect(h.forward().scrollOffset, isNull);
    });
  });

  group('AC 7: rewrite', () {
    test('rewrite replaces every matching entry and keeps offsets', () {
      var h = TabHistory<String>.initial('a').withScrollOffset(1);
      h = h.push('b').withScrollOffset(2);
      h = h.push('a').withScrollOffset(3);
      h = h.push('c').withScrollOffset(4);
      final r = h.rewrite('a', 'x');
      expect(r.entries, ['x', 'b', 'x', 'c']);
      expect(_offsets(r), [1.0, 2.0, 3.0, 4.0]);
    });

    test('rewrite leaves the index unchanged', () {
      final h = _at(_build(['a', 'b', 'a', 'c']), 1);
      final r = h.rewrite('a', 'x');
      expect(r.index, 1);
      expect(r.current, 'b');
      expect(r.canGoBack, isTrue);
      expect(r.canGoForward, isTrue);
    });

    test('rewrite of the current entry keeps it current with its offset', () {
      final h = _build(['a', 'b', 'c']).withScrollOffset(6);
      final r = h.rewrite('c', 'z');
      expect(r.current, 'z');
      expect(r.index, 2);
      expect(r.scrollOffset, 6);
    });

    test('rewrite with no matching entry changes nothing', () {
      final h = _at(_build(['a', 'b', 'c']), 1).withScrollOffset(2);
      final r = h.rewrite('q', 'x');
      expect(r, h);
      _expectSnap(r, index: 1, entries: ['a', 'b', 'c']);
    });

    test('rewrite does not merge neighbours that become equal', () {
      final r = _build(['a', 'b']).rewrite('b', 'a');
      expect(r.entries, ['a', 'a']);
      expect(r.index, 1);
    });

    test('rewrite onto a value other entries hold keeps every entry', () {
      final r = _build(['a', 'b', 'c']).rewrite('a', 'c');
      expect(r.entries, ['c', 'b', 'c']);
    });
  });

  group('AC 8 and 9: remove', () {
    TabHistory<String> five() => _at(_build(['a', 'b', 'c', 'd', 'e']), 2);

    test('remove of an entry before the current one keeps it current', () {
      final r = five().remove(0);
      _expectSnap(r, index: 1, entries: ['b', 'c', 'd', 'e']);
      expect(r.current, 'c');
    });

    test(
      'remove of the entry just before the current one keeps it current',
      () {
        final r = five().remove(1);
        _expectSnap(r, index: 1, entries: ['a', 'c', 'd', 'e']);
        expect(r.current, 'c');
      },
    );

    test('remove of the entry just after the current one keeps it current', () {
      final r = five().remove(3);
      _expectSnap(r, index: 2, entries: ['a', 'b', 'c', 'e']);
      expect(r.current, 'c');
    });

    test('remove of the last entry after the current one keeps it current', () {
      final r = five().remove(4);
      _expectSnap(r, index: 2, entries: ['a', 'b', 'c', 'd']);
      expect(r.current, 'c');
    });

    test(
      'remove of the current entry makes the one that took its place current',
      () {
        final r = five().remove(2);
        _expectSnap(r, index: 2, entries: ['a', 'b', 'd', 'e']);
        expect(r.current, 'd');
        expect(r.canGoForward, isTrue);
      },
    );

    test('remove of the current first entry makes the next entry current', () {
      final h = _at(_build(['a', 'b', 'c']), 0);
      final r = h.remove(0);
      _expectSnap(r, index: 0, entries: ['b', 'c']);
      expect(r.canGoBack, isFalse);
    });

    test(
      'remove of the current last entry makes the new last entry current',
      () {
        final r = _build(['a', 'b', 'c']).remove(2);
        _expectSnap(r, index: 1, entries: ['a', 'b']);
        expect(r.current, 'b');
        expect(r.canGoForward, isFalse);
      },
    );

    test('remove of the current entry from a two entry history', () {
      final h = _build(['a', 'b']);
      _expectSnap(h, index: 1, entries: ['a', 'b']);
      final r = h.remove(1);
      _expectSnap(r, index: 0, entries: ['a']);
      expect(r.canGoBack, isFalse);
      expect(r.canGoForward, isFalse);
    });

    test('remove keeps the offsets of the surviving entries', () {
      var h = TabHistory<String>.initial('a').withScrollOffset(1);
      h = h.push('b').withScrollOffset(2);
      h = h.push('c').withScrollOffset(3);
      h = h.push('d').withScrollOffset(4);
      h = _at(h, 2);
      expect(_offsets(h.remove(0)), [2.0, 3.0, 4.0]);
      expect(_offsets(h.remove(1)), [1.0, 3.0, 4.0]);
      expect(_offsets(h.remove(3)), [1.0, 2.0, 3.0]);
      // The entry that took the current one's place brings its own offset.
      final replaced = h.remove(2);
      expect(_offsets(replaced), [1.0, 2.0, 4.0]);
      expect(replaced.scrollOffset, 4);
      // Removing the last current entry lands on the entry before it.
      final last = _at(h, 3).remove(3);
      expect(last.scrollOffset, 3);
    });

    test('remove with an index below zero throws RangeError', () {
      expect(() => five().remove(-1), throwsRangeError);
    });

    test('remove with an index past the last entry throws RangeError', () {
      expect(() => five().remove(5), throwsRangeError);
    });

    test('remove of the only entry throws StateError', () {
      expect(() => TabHistory<String>.initial('a').remove(0), throwsStateError);
    });
  });

  group('value equality', () {
    TabHistory<String> make() {
      var h = TabHistory<String>.initial('a').withScrollOffset(1);
      h = h.push('b').withScrollOffset(2);
      return h;
    }

    test('histories built the same way are equal with equal hash codes', () {
      final x = make();
      final y = make();
      expect(identical(x, y), isFalse);
      expect(x, y);
      expect(x.hashCode, y.hashCode);
    });

    test('histories with different indexes are not equal', () {
      expect(make(), isNot(make().back()));
    });

    test('histories with different targets are not equal', () {
      final other = TabHistory<String>.initial(
        'a',
      ).withScrollOffset(1).push('c').withScrollOffset(2);
      expect(make(), isNot(other));
    });

    test('histories with different lengths are not equal', () {
      expect(make(), isNot(make().push('c')));
      expect(make().push('c'), isNot(make()));
    });

    test('histories with different offsets are not equal', () {
      final other = TabHistory<String>.initial(
        'a',
      ).withScrollOffset(1).push('b').withScrollOffset(3);
      expect(make(), isNot(other));
    });

    test('a null offset and a zero offset are not equal', () {
      final zero = TabHistory<String>.initial('a').withScrollOffset(0);
      expect(zero, isNot(TabHistory<String>.initial('a')));
    });

    test('equal histories hash alike for several shapes', () {
      final a = _build(['x', 'y', 'z']).back();
      final b = _build(['x', 'y', 'z']).back();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == _build(['x', 'y', 'z']), isFalse);
    });

    test('histories work over a non String target type', () {
      var a = TabHistory<int>.initial(1);
      a = a.push(2).push(3).back();
      var b = TabHistory<int>.initial(1);
      b = b.push(2).push(3).back();
      expect(a, b);
      expect(a.current, 2);
      expect(a.entries, [1, 2, 3]);
    });
  });

  group('AC 10: immutability', () {
    test('no operation changes the instance it was called on', () {
      var h = TabHistory<String>.initial('a').withScrollOffset(1);
      h = h.push('b').withScrollOffset(2);
      h = h.push('a').withScrollOffset(3);
      h = h.back();
      final before = _snap(h);
      final twin = _snap(h);

      h.push('z');
      expect(_snap(h), before, reason: 'push');
      h.back();
      expect(_snap(h), before, reason: 'back');
      h.forward();
      expect(_snap(h), before, reason: 'forward');
      h.withScrollOffset(77);
      expect(_snap(h), before, reason: 'withScrollOffset');
      h.rewrite('a', 'x');
      expect(_snap(h), before, reason: 'rewrite');
      h.remove(0);
      expect(_snap(h), before, reason: 'remove before');
      h.remove(1);
      expect(_snap(h), before, reason: 'remove current');
      h.remove(2);
      expect(_snap(h), before, reason: 'remove after');
      expect(_snap(h), twin);
    });

    test(
      'operations return new instances, not the receiver, when they change',
      () {
        final h = _build(['a', 'b', 'c']).back();
        expect(identical(h.push('d'), h), isFalse);
        expect(identical(h.back(), h), isFalse);
        expect(identical(h.forward(), h), isFalse);
        expect(identical(h.withScrollOffset(1), h), isFalse);
        expect(identical(h.rewrite('a', 'x'), h), isFalse);
        expect(identical(h.remove(0), h), isFalse);
      },
    );

    test('entries cannot be modified', () {
      final h = _build(['a', 'b', 'c']);
      expect(() => h.entries.add('d'), throwsUnsupportedError);
      expect(() => h.entries.removeLast(), throwsUnsupportedError);
      expect(() => h.entries.clear(), throwsUnsupportedError);
      expect(() => h.entries[0] = 'z', throwsUnsupportedError);
      expect(h.entries, ['a', 'b', 'c']);
    });

    test('entries of the initial history cannot be modified', () {
      final h = TabHistory<String>.initial('a');
      expect(() => h.entries.add('b'), throwsUnsupportedError);
      expect(h.entries, ['a']);
    });
  });
}
